# LoveVGM

A VGM player for [Löve2D](https://love2d.org/) written in pure Lua. No external dependencies

VGM is a format that logs register writes to real sound chips, so playing it back means actually emulating the hardware rather than just decoding audio. This only covers the Sega side of things — Genesis, Master System, 32X, Mega CD — and I, currently,  do not plan to add other systems. Both `.vgm` and `.vgz` (GZip compressed vgm) files work

## Running it

You need Löve2D, that's it. Version 11.5 or the upcoming 12 is recommended. Not tested on older versions

To browse files, make a `files/` folder in the project directory and put your VGMs in there. It'll show up as a sidebar on the left when you launch. You can also just drag and drop a file onto the window

Keyboard controls: space to play/pause, left/right to seek by 5 seconds, L to jump to the loop point, Home or 0 to restart, Escape to quit

If you want VGM files to try, [VGMRips](https://vgmrips.net/) has a large archive organized by system

## Code

The `vgm/` folder is the actual point of this project, for usage in any project you want. main.lua, and all the ui system is extra bits of this project, and while it works fine, the code is horrendous. And I'm not focusing on making it better

Contributions are welcome once I get the documentation written, which is still in progress

## License
Apache 2.0
