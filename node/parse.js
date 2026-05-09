#!/usr/bin/env node
// jsx_rosetta Node sidecar.
//
// Reads a JSON request from stdin, parses the source with @babel/parser,
// and writes a JSON response to stdout.
//
// Request:  { "source": "...", "typescript": false, "source_filename": "..." }
// Response (success): { "ok": true, "ast": <Babel File node> }
// Response (failure): { "ok": false, "error": { "message", "line", "column" } }
//
// Errors during stdin read or JSON parse exit with a non-zero status and
// print the error message to stderr.

"use strict";

const { parse } = require("@babel/parser");

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

function buildPlugins(typescript) {
  const plugins = ["jsx"];
  if (typescript) plugins.push("typescript");
  return plugins;
}

async function main() {
  const raw = await readStdin();
  let request;
  try {
    request = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`jsx_rosetta sidecar: invalid JSON request: ${e.message}\n`);
    process.exit(2);
  }

  const source = request.source ?? "";
  const typescript = Boolean(request.typescript);
  const sourceFilename = request.source_filename;

  try {
    const ast = parse(source, {
      sourceType: "module",
      sourceFilename,
      allowImportExportEverywhere: true,
      allowReturnOutsideFunction: true,
      plugins: buildPlugins(typescript),
      tokens: false,
      ranges: true,
    });
    process.stdout.write(JSON.stringify({ ok: true, ast }));
  } catch (err) {
    const response = {
      ok: false,
      error: {
        message: err.message,
        line: err.loc ? err.loc.line : null,
        column: err.loc ? err.loc.column : null,
      },
    };
    process.stdout.write(JSON.stringify(response));
  }
}

main().catch((err) => {
  process.stderr.write(`jsx_rosetta sidecar: unexpected error: ${err && err.stack ? err.stack : err}\n`);
  process.exit(1);
});
