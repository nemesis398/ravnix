#!/usr/bin/env python3
"""Opens Helium's DevTools in a headless Helium and reports how they look.

    devtools-probe.py HELIUM PROFILE_DIR [EXTRA_FLAG...]

Starts HELIUM headless (no sandbox, no GPU, dark mode forced, a debugging
port of the browser's choosing, in PROFILE_DIR), opens
devtools://devtools/bundled/devtools_app.html as a page over the Chrome
DevTools Protocol, waits for the frontend to draw, and prints one JSON object:

    roots     the shadow roots in the page, nested ones included
    squared   how many of them carry an adopted sheet that sets border-radius 0
    rounded   elements, in the document and in every shadow root, whose
              top-left corner is rounded
    dark      whether DevTools chose its dark theme
    primary   --sys-color-primary, resolved to a color (rgb(r, g, b))
    corner    --sys-shape-corner-small as declared
    font      --default-font-family as declared
    link      whether the document links catppuccin-mocha.css

The page is the frontend the browser serves under devtools://devtools/
bundled/, which is the custom one when --custom-devtools-frontend is set, by
the wrapper or as an EXTRA_FLAG. The browser is killed at the end, also when a
step fails; a failure exits with status 1 and a message on stderr.
"""
import asyncio
import json
import os
import subprocess
import sys
import time

import websockets

PROBE = r'''(async () => {
  // DevTools draws its panels after the first frames; wait until it has.
  for (let i = 0; i < 100 && !document.querySelector('.tabbed-pane, devtools-tabbed-pane, .main-tabbed-pane'); i++) {
    await new Promise(r => setTimeout(r, 100));
  }
  await new Promise(r => setTimeout(r, 1500));
  const roots = [];
  const walk = n => {
    for (const e of n.querySelectorAll('*')) {
      if (e.shadowRoot) { roots.push(e.shadowRoot); walk(e.shadowRoot); }
    }
  };
  walk(document);
  const square = s => [...s.cssRules].some(r => /border-radius: 0/.test(r.cssText));
  const squared = roots.filter(r => r.adoptedStyleSheets.some(square)).length;
  let rounded = 0;
  for (const n of [document, ...roots]) {
    for (const e of n.querySelectorAll('*')) {
      if (parseFloat(getComputedStyle(e).borderTopLeftRadius) > 0) rounded++;
    }
  }
  const probe = document.createElement('div');
  probe.style.color = 'var(--sys-color-primary)';
  document.body.append(probe);
  const primary = getComputedStyle(probe).color;
  probe.remove();
  const cs = getComputedStyle(document.documentElement);
  return JSON.stringify({
    roots: roots.length, squared, rounded,
    dark: document.documentElement.classList.contains('theme-with-dark-background'),
    primary,
    corner: cs.getPropertyValue('--sys-shape-corner-small').trim(),
    font: cs.getPropertyValue('--default-font-family').trim(),
    link: !!document.querySelector('link[href="./catppuccin-mocha.css"]'),
  });
})()'''


async def probe(port, path):
    async with websockets.connect(f'ws://127.0.0.1:{port}{path}', max_size=None) as ws:
        counter = 0

        async def call(method, params=None, session=None, tolerate=False):
            nonlocal counter
            counter += 1
            msg = {'id': counter, 'method': method, 'params': params or {}}
            if session:
                msg['sessionId'] = session
            await ws.send(json.dumps(msg))
            while True:
                reply = json.loads(await ws.recv())
                if reply.get('id') == counter:
                    if 'error' in reply:
                        if tolerate:
                            return None
                        raise SystemExit(f'{method}: {reply["error"]}')
                    return reply['result']

        target = await call('Target.createTarget',
                            {'url': 'devtools://devtools/bundled/devtools_app.html'})
        session = (await call('Target.attachToTarget',
                              {'targetId': target['targetId'], 'flatten': True}))['sessionId']
        # The target starts on about:blank and then navigates, which destroys
        # the first execution context; evaluate once the page is the frontend.
        for _ in range(100):
            await asyncio.sleep(0.2)
            here = await call('Runtime.evaluate', {
                'expression': 'location.href + " " + document.readyState',
                'returnByValue': True,
            }, session, tolerate=True)
            if here and here.get('result', {}).get('value', '').startswith('devtools://') \
                    and here['result']['value'].endswith('complete'):
                break
        else:
            raise SystemExit('the frontend did not load in 20 s')
        result = await call('Runtime.evaluate', {
            'expression': PROBE, 'awaitPromise': True, 'returnByValue': True,
        }, session)
        if 'exceptionDetails' in result:
            raise SystemExit(f'the probe failed: {result["exceptionDetails"]}')
        return result['result']['value']


def main():
    helium, profile, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(profile, exist_ok=True)
    port_file = os.path.join(profile, 'DevToolsActivePort')
    browser = subprocess.Popen(
        [helium, *extra, '--headless=new', '--no-sandbox', '--disable-gpu',
         '--force-dark-mode', f'--user-data-dir={profile}',
         '--remote-debugging-port=0', 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 60
        lines = []
        while time.monotonic() < deadline:
            if os.path.exists(port_file):
                lines = open(port_file).read().split('\n')
                if len(lines) >= 2 and lines[1]:
                    break
            if browser.poll() is not None:
                raise SystemExit(f'{helium} ended with status {browser.returncode}')
            time.sleep(0.1)
        else:
            raise SystemExit(f'{helium} wrote no debugging port in 60 s')
        print(asyncio.run(asyncio.wait_for(probe(lines[0], lines[1]), 120)))
    finally:
        browser.kill()
        browser.wait()


if __name__ == '__main__':
    main()
