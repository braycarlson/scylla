counter = 0


def bump():
    global counter
    counter = counter + 1


def read():
    return counter
