const http = require('http');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  if (req.url === '/health' || req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', timestamp: new Date().toISOString() }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Hello from Runtime Demo!\n');
});

server.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
