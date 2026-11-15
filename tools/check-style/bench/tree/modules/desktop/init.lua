-- No animations: no smooth scrolling, corner_radius = 4
vim.g.snacks_animate = false
vim.o.winborder = "single"
vim.o.pumblend = 0
vim.o.winblend = 0
local half = 6 // 2
return { ui = { border = "single" }, half = half }
