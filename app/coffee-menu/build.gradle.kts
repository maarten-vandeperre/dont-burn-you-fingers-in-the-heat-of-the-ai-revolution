// coffee-menu: the menu and price API of the coffee shop. Runs as v1 and v2 behind one Service,
// so the mesh can do canary / blue-green / mirroring and inject delays and errors (chaos).
// Only the shared dependencies from the root build are needed.
