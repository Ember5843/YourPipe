import fs from 'node:fs';
import path from 'node:path';

const sourceRoot = process.argv[2];
if (!sourceRoot) throw new Error('Usage: node build_local_ejs_bundle.mjs <yt-decoder-service/scripts>');

const solverPath = path.join(sourceRoot, 'solver_core.js');
let solver = fs.readFileSync(solverPath, 'utf8');
solver = solver.replace(
  '  function main(input) {',
  '  const preparedSolverCache = new Map();\n  function main(input) {'
).replace(
  '    const solvers = getFromPrepared(preprocessedPlayer);',
  '    let solvers;\n'
    + '    if (input.player_id) {\n'
    + '      solvers = preparedSolverCache.get(input.player_id);\n'
    + '      if (!solvers || input.replace_prepared) {\n'
    + '        solvers = getFromPrepared(preprocessedPlayer);\n'
    + '        preparedSolverCache.set(input.player_id, solvers);\n'
    + '      }\n'
    + '    } else {\n'
    + '      solvers = getFromPrepared(preprocessedPlayer);\n'
    + '    }'
);
if (!solver.includes('preparedSolverCache.set')) {
  throw new Error('solver_core.js cache transform did not apply');
}
const parts = [
  fs.readFileSync(path.join(sourceRoot, 'node_modules/meriyah/dist/meriyah.umd.min.js'), 'utf8'),
  fs.readFileSync(path.join(sourceRoot, 'node_modules/astring/dist/astring.min.js'), 'utf8'),
  solver,
];
const bundle = parts.join('\n')
  + '\nfunction __yourpipeEjs(inputJson){return JSON.stringify(jsc(JSON.parse(inputJson)));}\n';
// C++ raw-string delimiters are limited to 16 characters.
const delimiter = 'YPEJS';
if (bundle.includes(`)${delimiter}"`)) throw new Error('Raw string delimiter collision');

const output = `// Generated mechanically from the validated local yt-decoder-service EJS runtime.\n`
  + `// Sources: meriyah (ISC), astring (MIT), solver_core.js (Unlicense).\n`
  + `// Regenerate with youtube_core/scripts/build_local_ejs_bundle.mjs.\n`
  + `#pragma once\n#include <string_view>\n`
  + `inline constexpr std::string_view YOURPIPE_EJS_BUNDLE = R"${delimiter}(${bundle})${delimiter}";\n`;
const target = path.resolve('youtube_core/src/main/cpp/ejs_bundle.generated.h');
fs.writeFileSync(target, output, 'utf8');
console.log(`${target}: ${bundle.length} JS bytes`);
