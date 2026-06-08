// Shared JSON formatting helper for the workbook tooling scripts.
//
// The repo's split sources and the monolithic root JSON are stored with
// 2-space indentation, CRLF line endings, and a trailing newline — matching
// the format produced by the original split.js. Centralising this here keeps
// split.js and the add-show-* mutators byte-for-byte consistent.

/**
 * Serialise an object to the repo's canonical JSON-on-disk format:
 * 2-space indent, CRLF line endings, trailing CRLF.
 * @param {unknown} obj
 * @returns {string}
 */
function toCrlfJson(obj) {
  return JSON.stringify(obj, null, 2).replace(/\n/g, '\r\n') + '\r\n';
}

module.exports = { toCrlfJson };
