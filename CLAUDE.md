# remoteIGV

Lightweight web genome browser wrapping IGV.js. Python/FastAPI backend serves BAM/CRAM/VCF/BED files with HTTP range request support.

## Architecture

- `server.py` — FastAPI server, serves files from `--data-dir` with byte-range support
- `templates/index.html` — single-page frontend, loads IGV.js from CDN
- `aws/` — scripts to deploy on EC2 with S3 mount via mountpoint-s3
- Genome-wide annotation tracks (ENCODE cCREs, MANE Select, phyloP) are streamed directly from UCSC bigBed/bigWig URLs — not hosted locally

## Lessons

- This tool shipped without one-command remote access - the core use case. The README told users to SSH in, clone the repo, run commands on the server, then set up a tunnel manually. That's the exact friction the tool exists to eliminate. Always validate that the primary use case works end-to-end before polishing secondary features.

## Future directions

- **Variant-centric review** — load a VCF, click a variant, auto-navigate all loaded BAMs to that position. This is the core clinical/research review workflow.
- **Bookmarks and notes** — flag interesting regions, add comments, export as a report. Replaces the current workflow of screenshotting and pasting into slides.
