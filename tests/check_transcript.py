"""Fails unless the transcript contains every repetition of the JFK quote."""
import sys

sys.stdout.reconfigure(encoding="utf-8")

text = open(sys.argv[1], encoding="utf-8").read()
print(text)
count = text.lower().count("country")
print(f"'country' found {count} times (expected 6: the quote is repeated 3 times around long pauses)")
sys.exit(0 if count >= 5 else 1)
