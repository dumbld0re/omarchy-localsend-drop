import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// LocalSend Drop -- drag files onto the bar icon (or into the open panel),
// the panel opens and searches for LocalSend receivers, click one to send.
// All protocol work happens in bin/lsdrop.py, which speaks JSON lines.
Panel {
  id: root
  moduleName: "danny-miguel.localsend-drop"
  ipcTarget: "danny-miguel.localsend-drop"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string helper: Qt.resolvedUrl("bin/lsdrop.py").toString().replace("file://", "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var files: []          // absolute paths
  property var devices: []        // objects from `lsdrop.py discover`
  property bool searching: false
  property bool dragHover: false

  // idle | waiting | sending | done | error
  property string sendState: "idle"
  property string sendTarget: ""
  property string sendError: ""
  property real progress: 0
  property int cursor: -1

  readonly property bool sending: sendState === "waiting" || sendState === "sending"

  function urlToPath(url) {
    var s = url.toString()
    if (s.indexOf("file://") !== 0) return ""
    return decodeURIComponent(s.substring(7))
  }

  function addUrls(urls) {
    var next = files.slice()
    for (var i = 0; i < urls.length; i++) {
      var p = urlToPath(urls[i])
      if (p !== "" && next.indexOf(p) === -1) next.push(p)
    }
    files = next
    if (sendState === "done" || sendState === "error") sendState = "idle"
  }

  function baseName(p) {
    var i = p.lastIndexOf("/")
    return i >= 0 ? p.substring(i + 1) : p
  }

  function discover() {
    if (discoverProc.running) return
    devices = []
    cursor = -1
    searching = true
    discoverProc.command = ["python3", "-I", helper, "discover",
                            "--timeout", String(setting("discoverSeconds", 8))]
    discoverProc.running = true
  }

  function sendTo(device) {
    if (!device || files.length === 0 || sending) return
    sendTarget = device.alias
    sendError = ""
    progress = 0
    sendState = "waiting"
    sendProc.command = ["python3", "-I", helper, "send",
                        "--ip", device.ip, "--port", String(device.port),
                        "--protocol", device.protocol].concat(files)
    sendProc.running = true
  }

  function cancelSend() {
    if (sendProc.running) sendProc.running = false
    sendState = "idle"
  }

  function deviceGlyph(type) {
    switch (type) {
    case "mobile":   return "󰄜"
    case "desktop":  return "󰍹"
    case "web":      return "󰖟"
    case "headless": return "󰒋"
    case "server":   return "󰒋"
    default:         return "󰌢"
    }
  }

  function humanSize(bytes) {
    if (bytes < 1024) return bytes + " B"
    var units = ["KB", "MB", "GB"]
    var v = bytes
    for (var i = 0; i < units.length; i++) {
      v /= 1024
      if (v < 1024 || i === units.length - 1) return v.toFixed(v < 10 ? 1 : 0) + " " + units[i]
    }
  }

  onOpenedChanged: if (opened) {
    if (!sending && devices.length === 0) discover()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else if (sendState === "done" || sendState === "error") {
    sendState = "idle"
  }

  Process {
    id: discoverProc
    stdout: SplitParser {
      onRead: function(line) {
        var ev
        try { ev = JSON.parse(line) } catch (e) { return }
        if (ev.event === "device") root.devices = root.devices.concat([ev])
      }
    }
    onExited: root.searching = false
  }

  Process {
    id: sendProc
    stdout: SplitParser {
      onRead: function(line) {
        var ev
        try { ev = JSON.parse(line) } catch (e) { return }
        if (ev.event === "waiting") root.sendState = "waiting"
        else if (ev.event === "progress") {
          root.sendState = "sending"
          root.progress = ev.total > 0 ? ev.sent / ev.total : 1
        } else if (ev.event === "done") {
          root.sendState = "done"
          root.progress = 1
        } else if (ev.event === "error") {
          root.sendState = "error"
          root.sendError = ev.message
        }
      }
    }
    onExited: function(code) {
      if (root.sendState === "done") {
        Quickshell.execDetached(["notify-send", "-a", "LocalSend",
          "Sent to " + root.sendTarget,
          root.files.length === 1 ? root.baseName(root.files[0]) : root.files.length + " files"])
        root.files = []
        closeTimer.restart()
      } else if (root.sending) {
        root.sendState = "error"
        if (root.sendError === "") root.sendError = "Transfer stopped"
      }
    }
  }

  Timer {
    id: closeTimer
    interval: 1400
    onTriggered: if (root.sendState === "done") root.close()
  }

  // Dragging over the icon opens the panel so the drop target is obvious;
  // dropping on the icon itself works too.
  Timer {
    id: hoverOpen
    interval: 350
    onTriggered: if (root.dragHover && !root.opened) root.open()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function send(path: string): void { root.addUrls(["file://" + path]); root.open() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.sending ? "󰔟" : "󰒊"
    active: root.dragHover || root.sending
    tooltipText: root.files.length > 0 ? root.files.length + " file(s) ready — pick a receiver"
                                       : "LocalSend — drop files here"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) Quickshell.execDetached(["localsend"])
      else root.toggle()
    }

    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      onEntered: function(drag) {
        drag.accept(Qt.CopyAction)
        root.dragHover = true
        hoverOpen.restart()
      }
      onExited: root.dragHover = false
      onDropped: function(drop) {
        root.dragHover = false
        if (!drop.hasUrls) return
        drop.accept(Qt.CopyAction)
        root.addUrls(drop.urls)
        root.open()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.devices.length === 0) return
        root.cursor = Math.max(0, Math.min(root.devices.length - 1, root.cursor + dy))
      }
      onActivateRequested: if (root.cursor >= 0) root.sendTo(root.devices[root.cursor])
      onCloseRequested: root.close()
      onDeleteRequested: if (!root.sending) root.files = []
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.discover()
        else if (t === "o" || t === "O") Quickshell.execDetached(["localsend"])
      }

      // The whole panel accepts drops too, for adding more files.
      DropArea {
        id: panelDrop
        anchors.fill: parent
        keys: ["text/uri-list"]
        onEntered: function(drag) { drag.accept(Qt.CopyAction) }
        onDropped: function(drop) {
          if (!drop.hasUrls) return
          drop.accept(Qt.CopyAction)
          root.addUrls(drop.urls)
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "LocalSend"
            meta: root.sendState === "waiting" ? "Waiting for " + root.sendTarget + " to accept…"
                : root.sendState === "sending" ? "Sending to " + root.sendTarget + " · " + Math.round(root.progress * 100) + "%"
                : root.sendState === "done" ? "Sent to " + root.sendTarget
                : root.sendState === "error" ? root.sendError
                : root.files.length > 0 ? "Pick a receiver"
                : "Drop files here"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.sendState === "done" ? "󰄬" : root.sendState === "error" ? "󰅙" : "󰒊"
                color: root.sendState === "error" ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Progress bar while a transfer is running.
          Rectangle {
            visible: root.sending
            width: parent.width
            height: Style.space(4)
            radius: height / 2
            color: Qt.darker(root.foreground, 3)
            Rectangle {
              width: root.sendState === "waiting" ? parent.width * 0.15 : parent.width * root.progress
              height: parent.height
              radius: parent.radius
              color: root.foreground
              Behavior on width { NumberAnimation { duration: 150 } }
              SequentialAnimation on x {
                running: root.sendState === "waiting"
                loops: Animation.Infinite
                NumberAnimation { from: 0; to: column.width * 0.85; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { from: column.width * 0.85; to: 0; duration: 900; easing.type: Easing.InOutQuad }
              }
              onVisibleChanged: x = 0
            }
          }

          // ---------- files
          Rectangle {
            width: parent.width
            height: Math.max(Style.space(56), filesCol.implicitHeight + Style.space(16))
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: panelDrop.containsDrag ? root.foreground : Qt.darker(root.foreground, 2.2)

            Text {
              visible: root.files.length === 0
              anchors.centerIn: parent
              text: "󰁅  Drag files onto this panel or the bar icon"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              id: filesCol
              visible: root.files.length > 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(4)

              Repeater {
                model: root.files.slice(0, 6)
                RowLayout {
                  required property var modelData
                  required property int index
                  width: filesCol.width
                  spacing: Style.space(8)
                  Text {
                    text: "󰈔"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.baseName(modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideMiddle
                  }
                  Text {
                    visible: !root.sending
                    text: "󰅖"
                    color: removeMouse.containsMouse ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    MouseArea {
                      id: removeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var next = root.files.slice()
                        next.splice(index, 1)
                        root.files = next
                      }
                    }
                  }
                }
              }

              Text {
                visible: root.files.length > 6
                text: "+ " + (root.files.length - 6) + " more"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- receivers
          RowLayout {
            width: parent.width
            PanelSectionHeader {
              Layout.fillWidth: true
              text: root.searching ? "SEARCHING…" : "NEARBY DEVICES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Search again (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.searching
              onClicked: root.discover()
            }
            PanelActionButton {
              iconText: "󰏌"
              tooltipText: "Open LocalSend (o)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { Quickshell.execDetached(["localsend"]); root.close() }
            }
          }

          Text {
            visible: root.devices.length === 0
            width: parent.width
            text: root.searching ? "Looking for LocalSend devices on your network…"
                                 : "No devices found. Make sure LocalSend is open on the other device and on the same Wi-Fi."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: deviceCol
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.devices
              CursorSurface {
                id: row
                required property var modelData
                required property int index
                readonly property bool usable: root.files.length > 0 && !root.sending
                width: deviceCol.width
                implicitHeight: rowLayout.implicitHeight + Style.spacing.rowPaddingX
                hasCursor: root.cursor === index
                current: root.sending && root.sendTarget === modelData.alias
                foreground: root.foreground
                opacity: usable || current ? 1 : 0.55

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: row.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onEntered: root.cursor = row.index
                  onClicked: root.sendTo(row.modelData)
                }

                RowLayout {
                  id: rowLayout
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  Text {
                    text: root.deviceGlyph(row.modelData.deviceType)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)
                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: row.modelData.alias
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: (row.modelData.deviceModel ? row.modelData.deviceModel + " · " : "") + row.modelData.ip
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                  Text {
                    visible: row.usable
                    text: "󰒊"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          Text {
            visible: root.sending
            width: parent.width
            text: "Cancel"
            color: cancelMouse.containsMouse ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            MouseArea {
              id: cancelMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cancelSend()
            }
          }
        }
      }
    }
  }
}
