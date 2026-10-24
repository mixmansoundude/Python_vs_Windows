"""A tkinter window that opens, shows a label and closes itself after half a second."""
import tkinter as tk

root = tk.Tk()
root.title("Example window")
tk.Label(root, text="Hello from the example window").pack(padx=20, pady=20)
root.after(500, root.destroy)
root.mainloop()
print("window closed")
