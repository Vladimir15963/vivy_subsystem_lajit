extends Terminal

@onready var pty: PTY = $'../PTY'


func _ready():
    # terminal_path is already set in inspector to connect signals automatically

    # Fork a shell process
    var result = pty.fork()
    if result != OK:
        print("Failed to start shell: ", result)
