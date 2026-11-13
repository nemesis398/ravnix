// Square corners inside DevTools' shadow roots.
//
// catppuccin-mocha.css squares the main document, but most DevTools panels
// live in shadow DOM, where a document stylesheet does not apply. This runs
// before DevTools' own modules and appends one adopted stylesheet to every
// shadow root: once at attachShadow, and again whenever a component assigns
// its own adoptedStyleSheets list, which would otherwise drop ours.
const RULE = '*, *::before, *::after { border-radius: 0 !important; }';
const sheets = new WeakMap();  // one constructed sheet per document

function sheetFor(root) {
  const doc = root.ownerDocument || document;
  let sheet = sheets.get(doc);
  if (!sheet && doc.defaultView) {
    sheet = new doc.defaultView.CSSStyleSheet();
    sheet.replaceSync(RULE);
    sheets.set(doc, sheet);
  }
  return sheet;
}

const adopted = Object.getOwnPropertyDescriptor(ShadowRoot.prototype, 'adoptedStyleSheets');
if (adopted && adopted.set) {
  Object.defineProperty(ShadowRoot.prototype, 'adoptedStyleSheets', {
    ...adopted,
    set(list) {
      const sheet = sheetFor(this);
      try {
        adopted.set.call(this, sheet && !list.includes(sheet) ? [...list, sheet] : list);
      } catch {
        adopted.set.call(this, list);  // never break a panel over a corner
      }
    },
  });
  const attach = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function(init) {
    const root = attach.call(this, init);
    try {
      root.adoptedStyleSheets = [];  // the setter above adds ours
    } catch {
    }
    return root;
  };
}
