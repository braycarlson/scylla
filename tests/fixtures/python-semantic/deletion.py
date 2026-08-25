value = 1
del value
print(value)


def run():
    held = 2
    del held
    return held


def caught():
    try:
        pass
    except ValueError as error:
        print(error)

    return error
