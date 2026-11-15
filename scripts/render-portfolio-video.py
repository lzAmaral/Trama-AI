#!/usr/bin/env python3
"""Render the local portfolio timeline to a silent MP4 (requires Playwright + FFmpeg).

No live browser profile, account, provider or app window is accessed.
"""
from argparse import ArgumentParser
from pathlib import Path
import subprocess

from playwright.sync_api import sync_playwright


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.build/portfolio-video/trama-portfolio.mp4'))
    parser.add_argument('--fps', type=int, choices=[30, 60], default=60)
    parser.add_argument('--check', action='store_true', help='Check all 38 seconds at 10 fps, without encoding')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    timeline = root / 'docs/media/portfolio-source/timeline.html'
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(args=['--force-color-profile=srgb', '--allow-file-access-from-files'])
        try:
            page = browser.new_page(viewport={'width': 1080, 'height': 1080}, device_scale_factor=1)
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.goto(timeline.as_uri() + '?ar=1x1')
            page.wait_for_function('window.ready === true')
            duration = page.evaluate('window.DUR')
            if args.check:
                for frame in range(round(duration * 10)):
                    page.evaluate('window.seek', frame / 10)
                    failures = page.locator('[data-block], [data-role=focal]').evaluate_all('''nodes => nodes.filter(n => n.checkVisibility()).flatMap(n => {
                        const r=n.getBoundingClientRect();
                        return r.left < 89 || r.top < 89 || r.right > 991 || r.bottom > 991 ? [n.textContent || n.tagName] : [];
                    })''')
                    if failures:
                        raise RuntimeError(f'Layout at {frame / 10}s: {failures}')
                if errors:
                    raise RuntimeError(errors)
                print(f'Checked {round(duration * 10)} timeline samples; assets loaded, bounds and JS OK.')
                return
            output = args.output.resolve()
            if output.exists():
                raise FileExistsError(f'Choose a new output path; {output} already exists')
            output.parent.mkdir(parents=True, exist_ok=True)
            partial = output.with_suffix('.partial.mp4')
            if partial.exists():
                raise FileExistsError(partial)
            process = subprocess.Popen([
                'ffmpeg', '-v', 'error', '-f', 'image2pipe', '-vcodec', 'png', '-r', str(args.fps), '-i', '-',
                '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p',
                '-movflags', '+faststart', '-t', str(duration), str(partial)
            ], stdin=subprocess.PIPE)
            try:
                for frame in range(round(duration * args.fps)):
                    page.evaluate('window.seek', frame / args.fps)
                    if errors:
                        raise RuntimeError(errors)
                    process.stdin.write(page.screenshot(type='png'))
                process.stdin.close()
                if process.wait() != 0:
                    raise RuntimeError('FFmpeg failed; partial output preserved for diagnosis')
                partial.rename(output)
                print(output)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        finally:
            browser.close()


if __name__ == '__main__':
    main()
