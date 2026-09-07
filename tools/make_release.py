# Build a one-click-install release for Bolt's plugin manager.
#
#   python tools/make_release.py
#
# Produces dist/bolt-dg-v<version>.tar.gz (version read from bolt.json) and
# rewrites meta.json at the repo root:
#
#   { "sha256": ..., "version": ..., "url": ... }
#
# Bolt's installer (window_launcher.cxx InstallPlugin) extracts the archive
# with libarchive DIRECTLY into the plugin dir, so bolt.json must be at the
# ARCHIVE ROOT -- the archive holds the plugin folder's contents, not the
# folder. gzip because that is what Windows' bsdtar and every libarchive build
# can do; the installer enables all formats/filters.
#
# After running: upload the tarball as a release asset at the URL meta.json
# names, then commit meta.json. .github/workflows/release.yml does both on a
# `v<version>` tag push; this script is the same build, runnable by hand.
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(REPO, 'plugins', 'dg-map-tracker')
DIST = os.path.join(REPO, 'dist')

# Runtime files only: cataloguing/dev tooling stays out of user installs.
EXCLUDE_DIRS = { 'test', 'tools', '__pycache__' }


def origin_slug():
    """owner/repo of the `origin` remote.

    The release URL used to be a hardcoded owner. The repo moved accounts and
    the string did not, so meta.json went on naming a stale tarball under the
    OLD account: every URL install -- including fresh ones off the new repo's
    README -- silently got that old build, on a floor where half the features
    the map advertises simply were not there. A published pointer to somebody
    else's artifact is the one thing here that cannot be caught by reading the
    diff, so it is derived, never typed.
    """
    url = subprocess.check_output(
        ['git', '-C', REPO, 'remote', 'get-url', 'origin'], text=True).strip()
    m = re.search(r'(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$', url)
    if not m:
        raise SystemExit('cannot read owner/repo from origin remote: %s' % url)
    return m.group(1)


version = json.load(io.open(os.path.join(PLUGIN, 'bolt.json'), encoding='utf-8'))['version']
name = 'bolt-dg-v%s.tar.gz' % version
os.path.isdir(DIST) or os.makedirs(DIST)
out_path = os.path.join(DIST, name)

# GIT-TRACKED files only. Walking the directory swept in gitignored local
# working files (plan docs) on the first run -- a release must never contain
# anything the repo does not.
tracked = subprocess.check_output(
    ['git', '-C', REPO, 'ls-files', 'plugins/dg-map-tracker'], text=True).splitlines()
entries = []
for rel in sorted(tracked):
    arc = rel[len('plugins/dg-map-tracker/'):]
    if arc.split('/')[0] in EXCLUDE_DIRS:
        continue
    entries.append((os.path.join(REPO, rel.replace('/', os.sep)), arc))

# REPRODUCIBLE: the same tree must always produce the same bytes, because
# meta.json publishes a sha256 of them and the release workflow rebuilds the
# archive to check that claim. Three sources of drift, all pinned:
#   - the gzip header carries an mtime, which `tarfile.open(mode="w:gz")`
#     fills with the CURRENT TIME. That alone changed the sha on every run --
#     this file claimed determinism it did not have -- so the gzip stream is
#     opened explicitly with mtime=0 and no embedded filename.
#   - per-file mtime/ownership from the checkout (zeroed, as before).
#   - the local umask, via the file modes git hands back (normalised to
#     644, or 755 for anything git marks executable).
with open(out_path, 'wb') as raw:
    with gzip.GzipFile(filename='', mode='wb', compresslevel=9,
                       fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.GNU_FORMAT) as tf:
            for p, arc in entries:
                ti = tf.gettarinfo(p, arcname=arc)
                ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = 0, 0, 0, '', ''
                ti.mode = 0o755 if (ti.mode & 0o100) else 0o644
                with open(p, 'rb') as f:
                    tf.addfile(ti, f)

sha = hashlib.sha256(open(out_path, 'rb').read()).hexdigest()
meta = {
    'sha256': sha,
    'version': version,
    'url': 'https://github.com/%s/releases/download/v%s/%s' % (origin_slug(), version, name),
}
io.open(os.path.join(REPO, 'meta.json'), 'w', encoding='utf-8', newline='\n').write(
    json.dumps(meta, indent=2) + '\n')

print('archive : %s (%d files, %d bytes)' % (out_path, len(entries), os.path.getsize(out_path)))
print('sha256  : %s' % sha)
print('meta.json updated -> %s' % meta['url'])
