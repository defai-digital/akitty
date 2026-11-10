# Unreleased changes

Changes after AkiTTY 1.3.13; these are not yet part of a published release.

- A timed status or progress that the host receives and that expires before the PTY worker's next pass now clears on time, instead of waiting for the host's safety tick when an earlier status had just expired.
- Web direct scrolls (scroll methods, output following and scrollbar drags) now stop a running smooth scroll instead of being pulled back to its old target, and wheel ticks that arrive mid-animation add their full distance.
- Web asynchronous output retains its own copy of Buffer input, so reusing the caller's storage cannot corrupt queued text. Resetting from a bell callback stops the remaining bells from the old terminal.
- Web resizing clamps the viewport to the reflowed history and cancels smooth scrolling from the previous grid, keeping the display on retained rows.
