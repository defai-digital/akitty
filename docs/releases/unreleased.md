# Unreleased changes

Changes after AkiTTY 1.3.13; these are not yet part of a published release.

- A timed status or progress that the host receives and that expires before the PTY worker's next pass now clears on time, instead of waiting for the host's safety tick when an earlier status had just expired.
- Web direct scrolls (scroll methods, output following and scrollbar drags) now stop a running smooth scroll instead of being pulled back to its old target, and wheel ticks that arrive mid-animation add their full distance.
