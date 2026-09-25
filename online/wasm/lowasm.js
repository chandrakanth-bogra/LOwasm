/* -*- js-indent-level: 8 -*- */
/*
 * LOWASM: the host-facing API.
 *
 * The engine performs no HTTP of its own (see wasm/wasmapp.cpp). A host page
 * fetches a document however it likes -- presigned URL, its own API, a file
 * input -- and hands the bytes over:
 *
 *     await lowasm.ready;
 *     lowasm.on('saved', ({ name, bytes }) => upload(name, bytes));
 *     await lowasm.load('report.docx', bytes);
 *
 * Everything here is built on machinery that already exists: FS is an exported
 * runtime method, window.coolLoadDocument() opens a document on the warm
 * engine, and window.coolDocumentSaved()/coolDocumentLoadFailed() are the hooks
 * the engine calls. This file only gives them a name, a lifecycle and events.
 *
 * Loaded before bundle.js (see browser/html/cool.html.m4) so window.lowasm
 * exists by the time main.js runs.
 */
(function (global) {
	'use strict';

	var DOC_DIR = '/docs';

	var listeners = { ready: [], loaded: [], saved: [], error: [] };
	var currentName = null;
	var pendingLoad = null;
	// The client's socket is connected on the first load, not at boot: connecting
	// with no document sends 'load url=' and leaves WSD's session without a
	// document URL, after which it refuses tiles and saves alike.
	var connected = false;

	function emit(event, detail) {
		(listeners[event] || []).forEach(function (cb) {
			try {
				cb(detail);
			} catch (e) {
				// A throwing listener is the host's bug, not ours: report it and
				// keep the remaining listeners running.
				global.console.error('lowasm: ' + event + ' listener threw', e);
			}
		});
	}

	// The runtime is up once Emscripten has run main(). Polled rather than
	// hooked, because Module is created later by main.js -- this file is loaded
	// first on purpose, so there is nothing to attach to yet.
	var ready = new Promise(function (resolve) {
		var check = function () {
			if (global.Module && global.Module.calledRun && global.Module.FS) {
				resolve();
				emit('ready', {});
				return;
			}
			global.setTimeout(check, 50);
		};
		check();
	});

	function map() {
		return global.L && global.L.Map && global.L.Map.THIS;
	}

	// What CheckFileInfo would have provided in a WOPI deployment. There is no
	// WOPI in this build (WopiStorage is compiled out), but the client's toolbar,
	// title and Save As / Export naming all read these fields, so synthesize them.
	function announceDocument(name, canWrite) {
		var m = map();
		if (!m)
			return;
		m.fire('wopiprops', {
			BaseFileName: name,
			BreadcrumbDocName: name,
			UserCanWrite: canWrite,
			UserCanNotWriteRelative: true,
			SupportsRename: false,
			HideUserList: true,
			DisableCopy: false,
		});
	}

	// 'docloaded' fires with status true once the document layer is up. Attached
	// per load so a failed load does not leave a stale one-shot handler behind.
	function awaitDocLoaded(name) {
		return new Promise(function (resolve) {
			var m = map();
			if (!m) {
				resolve({ name: name });
				return;
			}
			var onLoaded = function (e) {
				if (e && e.status === false)
					return; // the teardown half of a document swap
				m.off('docloaded', onLoaded);
				var layer = m._docLayer || {};
				resolve({ name: name, docType: layer._docType, pages: layer._pages });
			};
			m.on('docloaded', onLoaded);
		});
	}

	function toBytes(bytes) {
		// instanceof is per-realm, so a framing host's ArrayBuffer fails it here.
		// Test the brand instead: isView() and the toString tag read internal
		// slots, which cross realms intact.
		if (ArrayBuffer.isView(bytes))
			return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);

		var tag = Object.prototype.toString.call(bytes);
		if (tag === '[object ArrayBuffer]' || tag === '[object SharedArrayBuffer]')
			return new Uint8Array(bytes);

		throw new TypeError('lowasm.load: bytes must be an ArrayBuffer or a typed array, got ' + tag);
	}

	global.lowasm = {
		ready: ready,

		/// Open a document from bytes the host already has. Resolves when the
		/// document layer reports itself loaded.
		load: function (name, bytes, options) {
			var opts = options || {};
			var data = toBytes(bytes);
			if (!name || name.indexOf('/') !== -1)
				throw new TypeError('lowasm.load: name must be a bare file name');

			return ready.then(function () {
				var FS = global.Module.FS;
				try {
					FS.mkdir(DOC_DIR);
				} catch (e) {
					// EEXIST on every load after the first.
				}

				// The extension is what LibreOffice uses to pick an import
				// filter, so the host's name is kept verbatim.
				var path = DOC_DIR + '/' + name;
				FS.writeFile(path, data);
				currentName = name;

				// Must precede the connect: Socket.ts only puts `readonly=1` on
				// the load message, and that is what makes the kit set the LOK
				// view read-only. Setting it later affects the UI alone.
				if (opts.canWrite === false)
					global.app.setPermission('readonly');

				pendingLoad = awaitDocLoaded(name);
				announceDocument(name, opts.canWrite !== false);

				// Set map.options.doc before connecting: Socket.ts sends
				// 'load url=' + that value, and WSD refuses every command (tiles
				// included) while it is empty. Later loads reuse the connection.
				var m = map();
				if (m)
					m.options.doc = 'file://' + path;
				global.coolLoadDocument('file://' + path);
				if (m && !connected) {
					connected = true;
					m.loadDocument(global.socket);
				}
				return pendingLoad.then(function (detail) {
					emit('loaded', detail);
					return detail;
				});
			});
		},

		/// Ask the engine to save. The bytes come back through the 'saved' event;
		/// sending `uno .uno:Save` instead would trip an assert in
		/// DocumentBroker and abort the engine.
		save: function () {
			var m = map();
			if (!m)
				return false;
			m.save(false /* dontTerminateEdit */, false /* dontSaveIfUnmodified */);
			return true;
		},

		/// 'ready' | 'loaded' | 'saved' | 'error'
		on: function (event, cb) {
			if (!listeners[event])
				throw new TypeError('lowasm.on: unknown event ' + event);
			listeners[event].push(cb);
			return function off() {
				listeners[event] = listeners[event].filter(function (f) { return f !== cb; });
			};
		},

		/// The document currently open, or null before the first load.
		get name() {
			return currentName;
		},
	};

	// The engine calls these two directly (wasm/wasmapp.cpp). global.js installs
	// logging defaults for both; overriding them here turns them into events
	// without removing that behaviour for anyone still using the hooks.
	global.coolDocumentSaved = function (name, bytes) {
		emit('saved', { name: name, bytes: bytes });
	};

	global.coolDocumentLoadFailed = function (url, status) {
		emit('error', { stage: 'load', name: currentName, url: url, status: status });
	};
})(window);
