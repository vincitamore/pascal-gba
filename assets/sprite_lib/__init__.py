"""sprite_lib -- agent-forward art harness for the Pascal-GBA pipeline.

Modules:
  util      shared helpers (size/rgb parsing, BGR555, modal-bg, chroma key, 4bpp pack, .inc emit)
  cost      append-only USD-ticks ledger
  xai       xAI Imagine / Video API client (OAuth + refresh + prompt-cache)
  bake      single-sprite + multi-frame baker (linear or OBJ tile order)
  tile      uniform-texture -> seamless tile (offset blend / mirror)
  pick      loop-detect + arc-length keyframe selection from a frame sequence
  review    montage / GIF / 3x3 tile / palette inspect / diff
  edit      variant via /images/edits + palette recolor + background re-key + sheet assembly
  extract   ffmpeg-backed frame extraction from video (optional host binary)
  emulate   stage a baked .inc into the generic sprite_smoke harness, build, run, capture PNGs
  registry  per-asset manifest tracking + canonical-reference registry

Driven from assets/sprite.py (the umbrella CLI). All commands accept --json and emit
deterministic artifacts; runs are idempotent via prompt-cache; every API call is
logged to the cost ledger.
"""

__version__ = "0.1.0"
