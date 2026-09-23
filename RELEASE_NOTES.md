# BarShelf 0.3.8

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

- **Power is a whole number again.** Menu bar readings dropped their decimal
  in 0.3.6, but the Sensors widget's power reading brought one back in 0.3.7
  (`3.6 W`). It now reads `4 W`, like every other reading. If you want the
  decimal, the item's **Decimals** setting still offers it.

- **You choose where a short number sits.** A reading keeps a steady width as
  it goes from one digit to two, so either the number or something around it
  has to give. New **Right-align numbers** setting in the Text row:
  - on (the default): the last digit and the unit stay still, and a one-digit
    reading leaves room in front of it;
  - off: the number starts where the label does, and the unit moves.

  Together with the row alignment (left, centre, right), that covers each way
  of lining the label up with the value. With the item aligned right, label
  and unit share a right edge, which is how system monitors usually draw it.
  Widgets can set a default (`numberAlignment`); your choice wins.
