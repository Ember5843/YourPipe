const fs = require('fs');
let content = fs.readFileSync('YTCoreLogger.ets', 'utf8');
content = content.replace(/\.\.\.args: string\[\]/g, '...args: Object[]');
content = content.replace(/args\.join\(' '\)/g, "args.map(a => typeof a === 'string' ? a : (a instanceof Error ? a.message : JSON.stringify(a))).join(' ')");
fs.writeFileSync('YTCoreLogger.ets', content);
