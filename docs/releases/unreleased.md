# Unreleased

- Reduce browser renderer allocation overhead while hashing rows for frame damage tracking.
- Reduce browser renderer color-string allocations while painting cell background runs.
- Drop frames drawn at the old scale when a terminal window moves between displays with different pixel densities.
- Reuse idle Metal bitmap textures during full redraws to reduce texture rotation under terminal output.
