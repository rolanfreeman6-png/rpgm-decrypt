/* No-op stub. bisect-ppx-report crashed before writing its bundled highlight.js
   on this Windows build; the per-file pages call hljs.initHighlightingOnLoad()
   inline, so this stub keeps them from throwing. Syntax highlighting is cosmetic;
   the visited/unvisited coverage colouring comes from coverage.css. */
var hljs = {
  initHighlightingOnLoad: function () {},
  highlightBlock: function () {},
  configure: function () {}
};
