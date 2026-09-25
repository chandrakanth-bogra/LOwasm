/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4; fill-column: 100 -*- */
/*
 * Copyright the Collabora Online contributors.
 *
 * SPDX-License-Identifier: MPL-2.0
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include <config.h>

#include "wasmapp.hpp"

#include <FakeSocket.hpp>
#include <Log.hpp>
#include <COOLWSD.hpp>
#include <Util.hpp>
#include <common/SigUtil.hpp>

#include <unistd.h>

#include <cassert>
#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>

int coolwsd_server_socket_fd = -1;

// The document currently open, written into the Emscripten filesystem by the
// host (see lowasm.js). Empty until the first load.
static std::string documentPath;
static std::string documentName;
static std::string fileURL;
static int fakeClientFd;
static int closeNotificationPipeForForwardingThread[2] = {-1, -1};

// LOWASM: one warm engine, many documents, opened one at a time.
//
// Upstream boots the module, fetches exactly one document and runs COOLWSD once
// -- so a second document meant a second module instance, paying the ~2-3s wasm
// compile, the ~2.2s MEMFS unpack and the LO bootstrap again. Instead we follow
// the Android app (android/lib/src/main/cpp/androidapp.cpp): keep the module and
// its filesystem alive and re-run COOLWSD per document.
//
// What makes this cheap is that the expensive LibreOffice state is already
// cached across runs -- kit/Kit.cpp holds `kit`/`loKit` in function-local
// statics, so lok_init_2() runs once however many times lokit_main does.
//
// Held while COOLWSD::run() is on the engine thread; closeDocument() acquires it
// to wait for that run to finish.
static std::mutex coolwsdRunningMutex;

// The next document to open, as a file:// URL. Written from the JS thread, read
// from the engine thread, so the mutex is required. The optional doubles as the
// "one is waiting" flag.
static std::mutex pendingMutex;
static std::condition_variable pendingCv;
static std::optional<std::string> pendingDocument;

static void send2JS(const std::vector<char>& buffer)
{
    MAIN_THREAD_EM_ASM({
        // Check if the message is binary. We say that any message that isn't just a single line is
        // "binary" even if that strictly speaking isn't the case; for instance the commandvalues:
        // message has a long bunch of non-binary JSON on multiple lines. But _onMessage() in
        // Socket.js handles it fine even if such a message, too, comes in as an ArrayBuffer. (Look
        // for the "textMsg = String.fromCharCode.apply(null, imgBytes);".)

        let newline = false;
        for (let i = 0; i != $1; ++i) {
            if (HEAPU8[$0 + i] === 0x0A) {
                newline = true;
                break;
            }
        }
        let data = HEAPU8.slice($0, $0 + $1);
        if (!newline) {
            data = new TextDecoder().decode(data);
        }

        globalThis.TheFakeWebSocket.onmessage({data});
    }, buffer.data(), buffer.size());
}

extern "C"
void handle_cool_message(const char *string_value)
{
    LOG_DBG("handle_cool_message(): '" << string_value << '\'');

    // LOWASM: snapshot the fd for this document. The global is reassigned by the
    // engine loop on the next open, and a forwarding thread from the previous
    // document may not have exited yet -- if it read the global it would poll
    // and write the *new* document's socket. That misroutes tiles rather than
    // failing outright, so it is worth the copy. Matches androidapp.cpp:155.
    const int currentFakeClientFd = fakeClientFd;

    if (strcmp(string_value, "HULLO") == 0)
    {
        // Now we know that the JS has started completely

        // Contact the permanently (during app lifetime) listening COOLWSD server
        // "public" socket
        assert(coolwsd_server_socket_fd != -1);
        int rc = fakeSocketConnect(currentFakeClientFd, coolwsd_server_socket_fd);
        assert(rc != -1);

        // Create a socket pair to notify the below thread when the document has been closed
        fakeSocketPipe2(closeNotificationPipeForForwardingThread);

        // Start another thread to read responses and forward them to the JavaScript
        std::thread([currentFakeClientFd]
                    {
                        Util::setThreadName("app2js");
                        while (true)
                        {
                           struct pollfd pollfd[2];
                           pollfd[0].fd = currentFakeClientFd;
                           pollfd[0].events = POLLIN;
                           pollfd[1].fd = closeNotificationPipeForForwardingThread[1];
                           pollfd[1].events = POLLIN;
                           if (fakeSocketPoll(pollfd, 2, -1) > 0)
                           {
                               if (pollfd[1].revents == POLLIN)
                               {
                                   // The code below handling the "BYE" fake Websocket
                                   // message has closed the other end of the
                                   // closeNotificationPipeForForwardingThread. Let's close
                                   // the other end too just for cleanliness, even if a
                                   // FakeSocket as such is not a system resource so nothing
                                   // is saved by closing it.
                                   fakeSocketClose(closeNotificationPipeForForwardingThread[1]);

                                   // Close our end of the fake socket connection to the
                                   // ClientSession thread, so that it terminates
                                   fakeSocketClose(currentFakeClientFd);

                                   return;
                               }
                               if (pollfd[0].revents == POLLIN)
                               {
                                   int n = fakeSocketAvailableDataLength(currentFakeClientFd);
                                   if (n == 0)
                                       return;
                                   std::vector<char> buf(n);
                                   n = fakeSocketRead(currentFakeClientFd, buf.data(), n);
                                   send2JS(buf);
                               }
                           }
                           else
                               break;
                       }
                       assert(false);
                    }).detach();

        // First we simply send it the URL. This corresponds to the GET request with Upgrade to
        // WebSocket.
        LOG_TRC_NOFILE("Actually sending to Online:" << fileURL);
        LOG_DBG("Loading file [" << fileURL << ']');

        fakeSocketWriteQueue(currentFakeClientFd, fileURL.c_str(), fileURL.size());
    }
    else if (strcmp(string_value, "BYE") == 0)
    {
        LOG_TRC_NOFILE("Document window terminating on JavaScript side. Closing our end of the socket.");

        // Close one end of the socket pair, that will wake up the forwarding thread above
        fakeSocketClose(closeNotificationPipeForForwardingThread[0]);
    }
    else
    {
        fakeSocketWriteQueue(currentFakeClientFd, string_value, strlen(string_value));
    }
}

namespace {
struct FileClose {
    void operator ()(FILE * f) { std::fclose(f); }
};
}

void saveToServer() {
    if (documentPath.empty()) {
        return;
    }
    const char* const path = documentPath.c_str();
    long n;
    std::unique_ptr<char[]> buf;
    {
        auto const f = std::unique_ptr<FILE, FileClose>(std::fopen(path, "r"));
        if (f.get() == nullptr) {
            LOG_WRN("Failed to open " << path << " for reading");
            return;
        }
        int e = std::fseek(f.get(), 0, SEEK_END);
        if (e != 0) {
            LOG_WRN("Failed to seek in " << path);
            return;
        }
        n = std::ftell(f.get());
        if (n == -1) {
            LOG_WRN("Failed to get size of " << path);
            return;
        }
        buf = std::make_unique<char[]>(n);
        std::rewind(f.get());
        std::size_t n2 = std::fread(buf.get(), 1, n, f.get());
        assert(n >= 0);
        if (n2 != static_cast<unsigned long>(n)) {
            LOG_WRN("Failed to read " << path);
            return;
        }
    }
    // LOWASM: there is no server to POST back to -- the host handed us the bytes
    // and the host takes them back. Mirrors reportLoadFailure's "call the global
    // hook if it exists" idiom and send2JS's HEAPU8.slice byte-passing idiom.
    // `documentName` identifies which document these bytes are, and is the same
    // name the host passed to lowasm.load().
    MAIN_THREAD_EM_ASM({
        if (typeof globalThis.coolDocumentSaved === 'function') {
            const bytes = HEAPU8.slice($0, $0 + $1);
            globalThis.coolDocumentSaved(UTF8ToString($2), bytes);
        }
    }, buf.get(), n, documentName.c_str());
    LOG_TRC("Saved " << path << " (" << n << " bytes), handed to coolDocumentSaved for <" << documentName << '>');
}

// Tell JS a document could not be opened. Must not exit: the instance is shared
// across documents, so one bad document cannot take the engine down with it.
static void reportLoadFailure(const std::string& url, int status)
{
    // global.js always installs a coolDocumentLoadFailed default, so there is
    // deliberately no fallback message here.
    LOG_ERR("Opening " << url << " failed, status: " << status);
    MAIN_THREAD_EM_ASM({
        if (typeof globalThis.coolDocumentLoadFailed === 'function')
            globalThis.coolDocumentLoadFailed(UTF8ToString($0), $1);
    }, url.c_str(), status);
}

/// "file:///docs/a.odt" -> "/docs/a.odt". Anything without the scheme is already
/// a filesystem path and is returned unchanged, so the host may pass either.
static std::string stripFileScheme(const std::string& url)
{
    constexpr std::string_view scheme = "file://";
    return url.starts_with(scheme) ? url.substr(scheme.size()) : url;
}

/// Point fileURL at the requested document, which the host has already written
/// into the Emscripten filesystem. Returns false if it is not there, in which
/// case the engine stays up and waits for the next request. The engine performs
/// no HTTP of its own; fetching is the host's business.
static bool prepareDocument(const std::string& desc)
{
    // The module outlives the document, so without this the previous one's bytes
    // would sit in MEMFS for the life of the tab.
    if (!documentPath.empty() && documentPath != stripFileScheme(desc))
        unlink(documentPath.c_str());

    documentPath = stripFileScheme(desc);
    documentName = documentPath.substr(documentPath.find_last_of('/') + 1);

    if (::access(documentPath.c_str(), R_OK) != 0)
    {
        documentPath.clear();
        documentName.clear();
        reportLoadFailure(desc, ENOENT);
        return false;
    }

    fileURL = desc;
    LOG_DBG("Opening " << fileURL);
    return true;
}

/// Close the current document and wait for the kit and COOLWSD to finish.
///
/// lokit_main holds COOLWSD::lokit_main_mutex for its whole life (COOLWSD.cpp),
/// and the engine loop holds coolwsdRunningMutex around COOLWSD::run(), so
/// acquiring both is a real barrier rather than a hopeful sleep.
static void closeDocument()
{
    fakeSocketClose(closeNotificationPipeForForwardingThread[0]);

    {
        // Scoped: we only want to know lokit_main has returned. Holding this
        // while waiting on coolwsdRunningMutex below would deadlock the next
        // run(), whose lokit_main thread takes this same mutex on entry.
        // Android holds both at once and gets away with it because its close is
        // terminal; ours is not.
        std::unique_lock<std::mutex> lokitLock(COOLWSD::lokit_main_mutex);
    }

    // LOWASM: upstream's close path does not do this, because upstream never
    // reuses the instance -- the tab was going away with the document. Two
    // separate loops have to be told to stop, and they read *different* flags:
    //
    //   COOLWSD::run()          while (!SigUtil::getShutdownRequestFlag())   >= ShutDown
    //   DocumentBroker::poll()  while (... && !SigUtil::getTerminationFlag()) >= Terminate
    //
    // requestShutdown() only raises the flag to ShutDown. That releases run()'s
    // poll loop but leaves the broker polling, so run() then blocks forever in
    // the unbounded docBroker->joinThread() during its shutdown sequence
    // (COOLWSD.cpp). Verified: with requestShutdown() the swap still hung at
    // 150s, having got past the bounded 30s DocBroker wait.
    //
    // setTerminationFlag() raises it to Terminate, which satisfies both
    // predicates. It is also exactly what the kit raises on the 'exit' command
    // (kit/KitWebSocket.cpp), so this is upstream's own stop signal, not a new
    // one. Skipping the graceful save is fine here and only here: the viewer is
    // read-only, and the kit has already finished by this point.
    //
    // COOLWSD::main() calls resetTerminationFlags() on entry, so the next run
    // starts from RunState::Run.
    SigUtil::setTerminationFlag();

    std::unique_lock<std::mutex> coolwsdLock(coolwsdRunningMutex);
}

static void engineLoop()
{
    Util::setThreadName("COOLWSD::run");

    char* argv[2];
    argv[0] = strdup("wasm");
    argv[1] = nullptr;

    while (true)
    {
        std::string desc;
        {
            std::unique_lock<std::mutex> lock(pendingMutex);
            pendingCv.wait(lock, [] { return pendingDocument.has_value(); });
            desc = std::move(*pendingDocument);
            pendingDocument.reset();
        }

        if (!prepareDocument(desc))
            continue; // engine stays warm; wait for the next request

        {
            std::unique_lock<std::mutex> lock(coolwsdRunningMutex);

            // Created here, not in main(), so each document gets a fresh client
            // socket. Safe despite JS being live already: the Emscripten build
            // never posts HULLO from JS (global.js gates it on
            // !ThisIsTheEmscriptenApp) -- COOLWSD::run() calls
            // handle_cool_message("HULLO") itself once its server socket is up,
            // by which point this fd exists.
            fakeClientFd = fakeSocketSocket();

            COOLWSD* coolwsd = new COOLWSD();
            coolwsd->run(1, argv);
            delete coolwsd;
        }

        // No throttle here, deliberately, unlike androidapp.cpp's copy of this
        // loop: that one re-enters run() immediately and sleeps to avoid a tight
        // spin, whereas this one blocks on pendingCv at the top. A sleep would
        // just add 100ms to the swap latency this whole mechanism exists to cut.
        LOG_DBG("One run of COOLWSD completed");
    }
}

/// Open a document on the warm engine, starting the engine on first use.
/// Safe to call from JS at any time; returns without blocking.
extern "C" void cool_load_document(const char* desc)
{
    LOG_DBG("cool_load_document(" << desc << ')');

    // Rejected here rather than queued: a bad descriptor from the host page
    // should not cost a teardown of the document currently on screen.
    if (desc == nullptr || *desc == '\0')
    {
        LOG_ERR("cool_load_document called with no document");
        return;
    }

    {
        std::lock_guard<std::mutex> lock(pendingMutex);
        pendingDocument = desc;
    }
    pendingCv.notify_one();

    // Only ever touched from the browser's main thread, which is the only caller
    // of this function (main() and the ccall from global.js are both on it).
    static bool engineStarted = false;
    if (!engineStarted)
    {
        engineStarted = true;
        std::thread(engineLoop).detach();
        return;
    }

    // A document is already open. Tear it down; the loop then picks up the
    // request queued above. Done on its own thread so the caller -- the browser's
    // main thread -- is not blocked on the teardown wait.
    std::thread(closeDocument).detach();
}

int main(int argc, char* argv_main[])
{
    Log::initialize("WASM", "error", false, false, {}, false, {});
    Util::setThreadName("main");

    fakeSocketSetLoggingCallback([](const std::string& line)
                                 {
                                     LOG_TRC_NOFILE(line);
                                 });

    // The module boots with no document and waits for lowasm.load(). A
    // descriptor on argv is optional, and only kept for a standalone page.
    if (argc > 1 && argv_main[1] != nullptr && *argv_main[1] != '\0')
        cool_load_document(argv_main[1]);

    return 0;
}

/* vim:set shiftwidth=4 softtabstop=4 expandtab cinoptions=b1,g0,N-s cinkeys+=0=break: */
