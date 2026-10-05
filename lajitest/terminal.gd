extends Control

@onready var terminal = $Terminal

# func _ready():
# 	# Write text to the terminal
# 	terminal.write("Hello, World!\n")

# 	# Write colored text using ANSI escape sequences
# 	terminal.write("\u001b[31mRed text\u001b[0m\n")
# 	terminal.write("\u001b[32mGreen text\u001b[0m\n")

# 	# Get terminal dimensions
# 	print("Terminal size: %d rows x %d columns" % [terminal.get_rows(), terminal.get_cols()])

# 	# Clear the terminal
# 	# terminal.clear()
@onready var pty = $PTY

func _ready():
	# Connect to signals
	pty.data_received.connect(_on_output)
	pty.exited.connect(_on_exit)

	# Start ping
	var result = pty.fork("ping", ["google.com"])
	if result != OK:
		print("Failed to start ping: ", result)
		return

	# Stop ping after 10 seconds
	await get_tree().create_timer(10.0).timeout
	print("Stopping ping...")
	pty.kill(2) # Send SIGINT to stop the process

func _on_output(data: PackedByteArray):
	var output = data.get_string_from_utf8()
	print("Shell output: ", output)

func _on_exit(exit_code: int, signal_code: int):
	print("Shell exited with code: ", exit_code)