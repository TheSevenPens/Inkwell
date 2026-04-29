
# Inkwell Overview

Inkwell is a MacOS native drawing application that takes advantage of a pressure-sensitive stylus to draw strokes.

# Initial Key features:

- Layers (bitmap layers now, vector layers in the future)
- Layer blend modes (like in Photoshop)
- Layer opacity
- Selections (like in Photoshop)
- Save/Export PSD, PNG, JPG
- Basic brushes: Marker, G-Pen, Airbrush, Eraser
- Brush settings: Name, Size, Map pressure to size (with pressure curve), Map Pressure to opacity (with pressure curve). 
- Image Rotation & Flipping
- Scaling the document (up/down)
- View control: Pan, Zoom, Rotate
- Undo/Redo

# Feature to to talk about later
- Load ABR format for brushes
- Distortion brushes (like blur, and liquify)
- Timelapse recording

# Supporting docs
- ARCHITECTURE.md - Identifies components, roles, relationships, and key technical decisions
- USERMANUAL.md - Standard user manual showing how to install, a quick tutorial, and explains feature set
- FUTURES.md - things we need to implement, address, fix - either now or in future releases
- PLAN.md - Phased implementation plan for building Inkwell incrementally
- FILEFORMAT.md - (to be authored) Detailed specification of the .inkwell native bundle format
