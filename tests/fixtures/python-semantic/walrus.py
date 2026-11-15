items = [1, 2, 3]
found = [total for value in items if (total := value * 2) > 2]
print(total)


def run():
    if (held := len(items)) > 0:
        return held

    return 0
