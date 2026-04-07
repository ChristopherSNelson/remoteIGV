# remoteIGV - Session Handoff (2026-04-06)

## What was done this session

- Added remote mode to `run.sh`: `./run.sh [-i key] user@host:/path` auto-deploys server, sets up SSH tunnel, opens browser
- Fixed Starlette `TemplateResponse` compatibility (newer API changed signature)
- Pinned dependency versions in `requirements.txt`
- Added port collision recovery (kills stale server before starting)
- Added `REMOTEIGV_SSH_OPTS` env var for default SSH key
- Auto-open browser on launch (suppressed on headless remotes via `REMOTEIGV_NO_OPEN`)
- Auto-load all BAM/CRAM files with indexes on startup (not just small files)
- Skip unindexed BAM/CRAM from file listing (IGV can't use them)
- Smart track naming: walks up parent dirs when filenames collide
- Gene model track now renders on top (switched from `genome: "hg38"` to explicit `reference` config)
- README rewritten: remote-first, documents SSH key options, simplified HPC section
- Tested live against Jurkat T cell ribo-seq/RNA-seq BAMs on AWS EFS

## Next steps (priority order)

1. Track naming could be shorter - consider stripping common suffixes like `align_star/Aligned.sortedByCoord.out.bam`
2. UI blocks while auto-loading many BAMs over SSH - consider loading tracks in parallel or showing a progress indicator
3. Variant-centric review (load VCF, click variant, navigate BAMs)
4. Bookmarks and notes

## Key decisions

- Used `reference` config instead of `genome: "hg38"` to control gene track ordering (avoids duplicate gene track)
- Auto-load all BAMs regardless of size since that's the primary use case
- SSH options parsed as CLI flags before the data dir argument, plus env var fallback
- Remote cleanup kills server process on exit to prevent port collision on next run

## Current blockers

- None
