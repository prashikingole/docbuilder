/**
 * Shows document previews without ever assigning HTML to innerHTML.
 *
 * The preview HTML is already built safely on the server (data values escaped, rich text cleaned with an
 * allowlist). This is a second, independent layer: the markup is parsed into an inert document, every
 * element and attribute outside a short allowlist is removed, and only then are the nodes moved into the page.
 */
const TAGS = new Set([
    'p', 'br', 'b', 'strong', 'i', 'em', 'u', 's', 'strike', 'ul', 'ol', 'li', 'span', 'div',
    'h1', 'h2', 'h3', 'h4', 'blockquote', 'sub', 'sup', 'hr',
    'table', 'thead', 'tbody', 'tr', 'th', 'td', 'img'
]);
const ATTRIBUTES = new Set(['class', 'style', 'colspan', 'rowspan', 'src', 'alt', 'aria-hidden']);
const FILE_PREFIX = '/sfc/servlet.shepherd/version/download/';
// Anything that can fetch a URL or run code from CSS, plus backslash escapes that could hide either.
const UNSAFE_STYLE = new RegExp('url\\s*\\(|expression\\s*\\(|javascript:|@import|\\\\', 'i');

function clean(parent) {
    Array.from(parent.children).forEach((element) => {
        const tag = element.tagName.toLowerCase();
        if (!TAGS.has(tag)) {
            element.remove();
            return;
        }
        Array.from(element.attributes).forEach((attribute) => {
            const name = attribute.name.toLowerCase();
            const value = attribute.value || '';
            const allowed =
                ATTRIBUTES.has(name) &&
                (name !== 'src' || (tag === 'img' && value.startsWith(FILE_PREFIX))) &&
                (name !== 'style' || !UNSAFE_STYLE.test(value));
            if (!allowed) {
                element.removeAttribute(attribute.name);
            }
        });
        clean(element);
    });
}

/** Replaces the contents of host with the cleaned preview. */
export function renderSafe(host, html) {
    while (host.firstChild) {
        host.removeChild(host.firstChild);
    }
    if (!html) {
        return;
    }
    const doc = new DOMParser().parseFromString('<div>' + html + '</div>', 'text/html');
    const root = doc.body.firstElementChild;
    if (!root) {
        return;
    }
    clean(root);
    Array.from(root.childNodes).forEach((node) => host.appendChild(document.importNode(node, true)));
}
