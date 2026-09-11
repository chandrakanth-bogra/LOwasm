// LOWASM: cache the big WASM payload so return visits skip the download (the
// HTTP disk cache evicts a 175 MB file readily). Populated as requests flow
// through -- no addAll on install, to avoid double-fetching on the first visit.
// Bump CACHE on every payload rebuild.
const CACHE = 'cool-payload-v1';
const PAYLOAD = ['online.js', 'online.wasm', 'soffice.data', 'soffice.data.js.metadata', 'bundle.js'];

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (e) => {
	e.waitUntil(
		caches.keys()
			.then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
			.then(() => self.clients.claim()),
	);
});

self.addEventListener('fetch', (e) => {
	const url = new URL(e.request.url);
	if (url.origin !== self.location.origin) return;
	if (!PAYLOAD.includes(url.pathname.split('/').pop())) return;
	e.respondWith(
		caches.open(CACHE).then((c) =>
			c.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
				if (res.ok) c.put(e.request, res.clone());
				return res;
			})),
		),
	);
});
