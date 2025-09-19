const express = require('express');
const { execSync } = require('child_process');

const app = express();
const port = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.json({
    message: 'Deterministic build practice app',
    timestamp: new Date().toISOString(),
    nodeVersion: process.version
  });
});

app.get('/health', (req, res) => {
  try {
    const curlVersion = execSync('curl --version', { encoding: 'utf8' });
    res.json({
      status: 'healthy',
      curl: curlVersion.split('\n')[0]
    });
  } catch (error) {
    res.status(500).json({ status: 'error', message: error.message });
  }
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});