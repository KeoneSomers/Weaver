# Repository loading

Working-tree reads are progressive. libgit2 loads repository metadata and recent
history. One NUL-delimited Git status command lists changed paths, including both
staged and unstaged entries, renames, conflicts and nested untracked files. Git
remains responsible for clean filters and LFS status.

On Windows, automatic refresh waits for native recursive directory-change
notifications instead of running Git status every five seconds. The working
directory and any external Git directories are watched, including linked
worktrees' shared refs and individual indexes. Bursts settle for 750 ms, with a
two-second maximum delay during continuous writes. Reads do not trigger the watch.
An unchanged, watched repository does not run periodic status, counts or previews.
Other platforms and unavailable/failed watches use a quiet 30-second fallback.
Git's existing fsmonitor and untracked-cache configuration is preserved.

Automatic reads keep controls available and retain selection, scroll position,
line counts and the existing preview while replacements load. Identical status
lists are retained; selected content is still checked because a second edit can
leave a file's Git status unchanged. Identical patches keep their parsed diff
rows. Background refresh does not animate the loading status or replace notices.
F5 and the Refresh action remain explicit foreground reads. Filesystem signals
only invalidate cached data; Git still decides which changes and filters count.

The UI displays this list before generating patches. Two batched Git numstat
commands obtain tracked line counts in the background; untracked files are counted
one buffer at a time. Only the selected working-tree file gets a parsed diff.
Previews are bounded to 2 MiB and 25,000 lines. Counts can still be available when
a tracked preview exceeds these limits. Oversized/unreadable untracked files show
unavailable counts rather than a misleading zero.

Changed-file rows are virtualized. Unified and split diff row metadata is cached
until the selected preview changes. Quick selections are debounced. Repository
and selection generations reject outdated background results. Repository reads
can overlap when switching; previous reads finish in the background. Git writes
remain serialized. The Knots completion patch explicitly releases owned results
that shutdown discards.

## Local Windows measurements

ReleaseSafe build, 3,000 modified tracked files and 2,000 untracked files, each with
180 lines. Every tracked line changed. Three sequential runs on the same machine,
with normal filesystem caching; these are synthetic local results, not guarantees
for another repository or disk.

| Operation | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Previous eager provider load | 16.034 s | 10.832 s | 11.260 s | 11.260 s |
| New file-list scan | 0.283 s | 0.278 s | 0.275 s | 0.278 s |
| New scan + counts + one preview, sequential | 6.720 s | 4.366 s | 4.314 s | 4.366 s |

The app starts the selected preview independently of counts. The previous provider
retained 20,799,000 patch bytes and 1,095,000 parsed lines before returning; the new
scan retains neither. The selected preview in this fixture is 6,933 bytes. The old
app also expanded untracked previews after the measured eager provider call, so
the old-provider measurement excludes that additional work.

The headless inspector can reproduce provider measurements against a chosen test
repository. Time separate processes to compare `--benchmark eager`, `--benchmark
scan`, and `--benchmark progressive`, each followed by an absolute repository
path. `zig build check -Dheadless=true -Doptimize=ReleaseSafe` builds the inspector.

Native Windows checks verified that only 14 file buttons were present for 5,000
changes at the tested window size, scrolling changed the visible band, filtering
selected a distant file, and its diff loaded. A deliberately slow clean-filter
fixture verified visible loading, switching during status, rejection of stale
results, and clean shutdown during a scan. Native file-picker regression checks
also passed. Other operating systems have not been runtime-tested here.

A separate Windows refresh fixture logged clean-filter invocations outside its
watched repository. After loading settled, seven idle seconds produced no Git
status/diff reads. Editing an already-modified file updated its selected patch
while repository controls remained enabled; adding an earlier file retained the
selection. Closing the app cancelled its pending native watcher cleanly. Backend
tests also cover nested paths, renames, deletions, staging, shared worktree refs,
internal Git-event filtering and cancellation.
