import sys

target = 0xAB9F
found = False
with open('win9x/winme/build/kernel32.lst', 'r', encoding='latin-1') as f:
    for i, line in enumerate(f):
        parts = line.split()
        if len(parts) >= 2:
            try:
                # The second column is usually the offset
                offset = int(parts[1], 16)
                if offset >= target:
                    print(f"Line {i+1}: {line.strip()}")
                    found = True
                    break
            except ValueError:
                pass

if not found:
    print("Not found")
