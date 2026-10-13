# Corrections from the final stress audit (S01–S15)

Scope: the final 2026-10-13 stress audit, based on 464ff92. Earlier audit findings are outside this change.

| Finding | Correction |
| --- | --- |
| S01 | Child events carry PID plus `ended`; GUI and Telegram track every active child group. Cancellation terminates all registered groups and waits before releasing the remote worker. |
| S02 | Loading validates unique UUIDs and counters before recovery/save/cleanup. Job paths cannot contain traversal. Symlinks outside the jobs directory block cleanup and execution. |
| S03 | Unicode decimal digits become ASCII after URL/email protection. Overlong ordinal conversion and Int.min produce errors instead of traps. |
| S04–S05 | A completion checkpoint without a matching fingerprint is discarded. Dropbox negative metadata clears the completion claim and forces upload. Saved links are revalidated; Google links are reconstructed from the verified ID. Network/permission failures preserve the local copy. |
| S06 | Project import/export rewrites only own sample paths and the music setting, preserving source text, utterances and instructions. |
| S07–S08 | Clamp percentage before integer conversion; check SACC offsets using bounded subtraction. |
| S09 | Stress helper has a request deadline, bounded response and TERM/KILL shutdown; SIGPIPE becomes an error. |
| S10 | Repeated Google 308 acknowledgements without increased offset receive backoff and stop after a bounded number of attempts. |
| S11 | Non-idempotent POST creation is not automatically repeated after an ambiguous response. Explicitly safe metadata/offset requests keep retries. An uncertain folder creation fails visibly rather than silently duplicating its mutation. |
| S12 | Long HTML is converted to plain text preserving link targets, then split within UTF-16 limits. Short valid HTML is retained intact. |
| S13 | File names reserve byte space for extensions and suffixes; project/import/original-copy names follow the same bound. |
| S14 | SPC payload decompression uses a fixed expected output buffer; file size is checked before reading. SPC1 and SPC2 remain supported. |
| S15 | ZIP/ZIP64 directory preflight bounds expanded bytes, members and directory size. Check disk space, impose a child-only per-file limit, monitor actual extraction against declared size, verify final output and remove failed extraction. |

The supplementary static OAuth finding is also corrected: request fragments accumulate up to CRLF with an 8192-byte ceiling instead of treating the first TCP fragment as the complete request.

Default extraction budgets: books 8 GiB / 50,000 members; projects 64 GiB total / 16 GiB per member / 200,000 members; central directory at most 64 MiB. At least 256 MiB of free disk remains after the declared extraction. Large legitimate projects retain ZIP64 support. A declared per-file budget is applied to the extraction process only, not to the application or synthesis workers.

Validation: 66 StudioCore tests and 31 StudioRemote tests passed locally using a minimal XCTest stand-in with Command Line Tools; optimized GUI compilation passed. New regressions cover original traps, altered cloud files, missing fingerprints, deleted links, stalled uploads, UUID traversal/symlinks, concurrent children, helper deadlines, source URI round-trip with music relocation, Unicode file names, compressed over-expansion, forged ZIP size and ZIP64 size accounting. GitHub Actions runs the real XCTest suite and full Release packaging before installation.

No real paid LLM/TTS calls or cloud writes were used in local tests. A prolonged RSS/Metal measurement of actual synthesis remains separate work; these corrections do not establish absence of every memory leak.
