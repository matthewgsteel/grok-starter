import http from 'node:http';

const upstreamHost = '127.0.0.1';
const upstreamPort = 8012;
const upstreamPath = '/mcp';
const listenHost = '127.0.0.1';
const listenPort = 8013;

const server = http.createServer((req, res) => {
  const query = req.url?.includes('?') ? req.url.slice(req.url.indexOf('?')) : '';
  const upstream = http.request({
    host: upstreamHost,
    port: upstreamPort,
    path: upstreamPath + query,
    method: req.method,
    headers: { ...req.headers, host: `${upstreamHost}:${upstreamPort}` }
  }, (upstreamResponse) => {
    res.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
    upstreamResponse.pipe(res);
  });

  upstream.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('upstream unavailable');
  });

  req.pipe(upstream);
});

server.listen(listenPort, listenHost, () => {
  console.error(`proton-pass rewrite proxy listening on ${listenHost}:${listenPort}`);
});
