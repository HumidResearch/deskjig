JSON-BASED ACTION PANEL CONFIGURATION SYSTEM
=============================================

The Action Panel now uses JSON configuration files to define its menu structure.

USAGE
-----

1. ActionPanelManager automatically loads "menu-default.json" on initialization
2. To use a different config, pass the filename (without .json):

   let manager = ActionPanelManager(
       workspaceVM: workspaceVM,
       configurationFile: "menu-minimalist"
   )

CONFIGURATION FILES
-------------------

menu-default.json     - Full-featured menu with windows and settings
menu-minimalist.json  - Simple 2-button layout (workspaces + settings)

FILE STRUCTURE
--------------

{
  "version": "1.0",
  "settings": { ... },           // Optional global settings
  "rootItems": [                 // Top-level menu items
    {
      "id": "unique-id",
      "title": "Button Text",
      "subtitle": "Optional",    // Shows below title
      "icon": {
        "type": "systemImage",   // or "emoji"
        "value": "gear"          // SF Symbol name or emoji
      },
      "type": "branch",          // or "leaf", "dynamic", "separator"
      "children": [...],         // Sub-items for branch types
      "action": "app.settings",  // Action for leaf types
      "actionParameters": {...}, // Optional action parameters
      "visibilityRule": {             // Optional visibility rule
        "condition": "hasWorkspaces"
      },
      "shortcuts": ["cmd+,"]     // Optional keyboard shortcuts
    }
  ]
}

ITEM TYPES
----------

branch    - Has children, reveals submenu when clicked
leaf      - Executes an action when clicked
dynamic   - Populated at runtime (e.g., workspace list)
separator - Visual separator (not rendered in current UI style)

AVAILABLE ACTIONS
-----------------

Window Actions:
  window.close, window.closeApp, window.hide, window.minimize,
  window.restore, window.activate, window.moveLeft, window.moveRight,
  window.moveUp, window.moveDown, window.center, window.maximize,
  window.leftHalf, window.rightHalf, window.hideAll, window.minimizeAll

Workspace Actions:
  workspace.create, workspace.save, workspace.delete, workspace.rename,
  workspace.edit, workspace.open, workspace.restore, workspace.reload

App Actions:
  app.settings, app.quit, app.about, app.checkUpdates

VISIBILITY CONDITIONS
--------------------

hasWorkspaces      - User has saved workspaces
isWindowFocused    - A window is currently focused
hasMultipleScreens - Multiple displays connected

DYNAMIC ITEMS
-------------

Items with id "workspaces" or "workspaces.list" will automatically
be populated with the user's saved workspaces at runtime.

EXAMPLE
-------

{
  "version": "1.0",
  "rootItems": [
    {
      "id": "windows",
      "title": "Windows",
      "icon": {"type": "systemImage", "value": "macwindow"},
      "type": "branch",
      "children": [
        {
          "id": "windows.close",
          "title": "Close Window",
          "type": "leaf",
          "action": "window.close"
        }
      ]
    }
  ]
}

