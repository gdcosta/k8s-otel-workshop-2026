#!/usr/bin/env python3
"""Turn a MkDocs build into fully self-contained single HTML files.

Every stylesheet, script and image is inlined (data: URI), inter-page links are
rewritten to flat sibling filenames, and the search worker is removed. The result
is a folder of independent .html files with no asset directory — each one opens
correctly from a file share, SharePoint, a USB stick, or an email attachment.

Usage: inline_standalone.py <built-site-dir> <output-dir>
"""
import base64, mimetypes, os, re, shutil, sys

SRC, DST = sys.argv[1], sys.argv[2]


def flat_name(rel):
    """docs/01-foundational-1/index.html -> 01-foundational-1.html"""
    rel = rel.replace(os.sep, '/')
    if rel == 'index.html':
        return 'index.html'
    if rel.endswith('/index.html'):
        return rel[:-len('/index.html')].replace('/', '-') + '.html'
    return rel.replace('/', '-')


def data_uri(path):
    mime = mimetypes.guess_type(path)[0] or 'application/octet-stream'
    with open(path, 'rb') as fh:
        return f"data:{mime};base64," + base64.b64encode(fh.read()).decode('ascii')


def resolve(page_dir, url):
    url = url.split('#')[0].split('?')[0]
    if not url or url.startswith(('http://', 'https://', 'data:', 'mailto:', '#')):
        return None
    p = os.path.normpath(os.path.join(page_dir, url))
    return p if os.path.isfile(p) else None


pages = []
for d, _, fs in os.walk(SRC):
    for f in fs:
        if f.endswith('.html') and f != '404.html':
            pages.append(os.path.relpath(os.path.join(d, f), SRC))

os.makedirs(DST, exist_ok=True)
link_map = {p.replace(os.sep, '/'): flat_name(p) for p in pages}
report = []

for rel in sorted(pages):
    src = os.path.join(SRC, rel)
    page_dir = os.path.dirname(src)
    html = open(src, encoding='utf8').read()

    # 1. stylesheets -> <style>
    def css(m):
        p = resolve(page_dir, m.group(1))
        if not p:
            return m.group(0)
        return '<style>' + open(p, encoding='utf8').read() + '</style>'
    html = re.sub(r'<link[^>]+rel="stylesheet"[^>]*href="([^"]+)"[^>]*>', css, html)
    html = re.sub(r'<link[^>]+href="([^"]+)"[^>]*rel="stylesheet"[^>]*>', css, html)

    # 1b. favicon & touch icons -> data: URI
    def icon(m):
        p = resolve(page_dir, m.group(2))
        return f'<link{m.group(1)}href="{data_uri(p)}"{m.group(3)}>' if p else m.group(0)
    html = re.sub(r'<link([^>]*rel="(?:icon|shortcut icon|apple-touch-icon)"[^>]*?)'
                  r'href="([^"]+)"([^>]*?)>', icon, html)
    html = re.sub(r'<link([^>]*?)href="([^"]+)"([^>]*rel="(?:icon|shortcut icon|'
                  r'apple-touch-icon)"[^>]*?)>', icon, html)

    # 2. drop the search worker + its shim entirely — a Worker cannot be created
    #    from a file:// origin, and an uncaught error there breaks the rest of the
    #    theme's JS. Per-page Ctrl-F replaces it.
    html = re.sub(r'<script[^>]*iframe-worker[^>]*>\s*</script>', '', html)
    html = re.sub(r'<script[^>]*search_index[^>]*>\s*</script>', '', html)
    html = re.sub(r'<div[^>]+class="md-search"[^>]*>.*?</div>\s*(?=<div|<nav|</header)',
                  '', html, flags=re.S)

    # 3. scripts -> inline
    def js(m):
        p = resolve(page_dir, m.group(1))
        if not p:
            return m.group(0)
        body = open(p, encoding='utf8', errors='replace').read()
        body = body.replace('</script>', '<\\/script>')
        return '<script>' + body + '</script>'
    html = re.sub(r'<script[^>]*src="([^"]+)"[^>]*>\s*</script>', js, html)

    # 4. images -> data: URI
    def img(m):
        pre, url, post = m.group(1), m.group(2), m.group(3)
        p = resolve(page_dir, url)
        return f'<img{pre}src="{data_uri(p)}"{post}>' if p else m.group(0)
    html = re.sub(r'<img([^>]*?)src="([^"]+)"([^>]*?)>', img, html)

    # 5. inter-page links -> flat sibling filenames
    def link(m):
        url = m.group(1)
        if url.startswith(('http', 'data:', 'mailto:', '#')):
            return m.group(0)
        frag = ''
        if '#' in url:
            url, frag = url.split('#', 1)
            frag = '#' + frag
        if not url:
            return m.group(0)
        target = os.path.normpath(os.path.join(os.path.dirname(rel), url)).replace(os.sep, '/')
        if target in link_map:
            return f'href="{link_map[target]}{frag}"'
        return m.group(0)
    html = re.sub(r'href="([^"]+)"', link, html)

    # 6. make the theme's startup survive hosts that aren't a normal browser tab.
    #    In a preview pane or sandboxed iframe, `location` is about:srcdoc (no base
    #    URL to resolve ".." against) and localStorage/sessionStorage can throw. Left
    #    alone, the first inline script dies on `new URL("..", location)`, `__md_get`
    #    is then never defined, and the bundle dies on the same call again. Each
    #    patch must match exactly once per page: if a MkDocs Material upgrade
    #    changes this code, fail the build rather than silently ship the old bug.
    def patch(h, old, new, what):
        if h.count(old) != 1:
            sys.exit(f"  ! {rel}: cannot apply preview-pane patch '{what}' "
                     f"({h.count(old)} matches) — did mkdocs-material change?")
        return h.replace(old, new)
    # The relative path differs by page depth (".." for most, "." for the home page).
    scope = re.search(r'__md_scope=new URL\("(\.{1,2})",location\)', html)
    if not scope:
        sys.exit(f"  ! {rel}: cannot apply preview-pane patch '__md_scope' — did mkdocs-material change?")
    html = patch(html, scope.group(0),
                 f'__md_scope=(()=>{{try{{return new URL("{scope.group(1)}",location)}}'
                 'catch(e){return new URL("file:///")}})()', '__md_scope')
    html = patch(html, '__md_get=(e,_=localStorage,t=__md_scope)=>JSON.parse(_.getItem(t.pathname+"."+e))',
                 '__md_get=(e,_,t=__md_scope)=>{try{return JSON.parse((_||localStorage)'
                 '.getItem(t.pathname+"."+e))}catch(r){return null}}', '__md_get')
    html = patch(html, '__md_set=(e,_,t=localStorage,a=__md_scope)=>{try{t.setItem(',
                 '__md_set=(e,_,t,a=__md_scope)=>{try{(t||localStorage).setItem(', '__md_set')
    html = patch(html, 'Ct.base=`${new URL(Ct.base,we())}`;',
                 'Ct.base=`${(()=>{try{return new URL(Ct.base,we())}'
                 'catch(e){return new URL("file:///")}})()}`;', 'config base')
    # The bundle's source-map comment points at a file that is not shipped; DevTools
    # logs a failed fetch for it on every page.
    html = re.sub(r'//# sourceMappingURL=\S+', '', html)

    out = os.path.join(DST, flat_name(rel))
    with open(out, 'w', encoding='utf8') as fh:
        fh.write(html)
    report.append((flat_name(rel), os.path.getsize(out)))

print(f"  {len(report)} standalone files -> {DST}/\n")
print(f"  {'FILE':<34}{'SIZE':>10}")
total = 0
for n, s in sorted(report):
    total += s
    print(f"  {n:<34}{s/1024:>9.0f}K")
print(f"  {'':<34}{'-'*9}")
print(f"  {'total':<34}{total/1048576:>8.1f}M")

leftovers = set()
for n, _ in report:
    h = open(os.path.join(DST, n), encoding='utf8').read()
    for m in re.finditer(r'(?:src|href)="(?!https?://|data:|mailto:|#)([^"]+)"', h):
        u = m.group(1)
        if not u.split('#')[0].endswith('.html'):   # sibling page links may carry anchors
            leftovers.add(u)
print(f"\n  remaining external file references: {len(leftovers)}")
for u in sorted(leftovers)[:5]:
    print(f"    ! {u}")
