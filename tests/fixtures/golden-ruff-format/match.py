def handle(command):
    match command:
        case 1:
            pass
        case "text":
            pass
        case [a, b]:
            pass
        case [a, *rest]:
            pass
        case {"key": value}:
            pass
        case {"key": value, **rest}:
            pass
        case Point(x=0, y=0):
            pass
        case Point(0, 0):
            pass
        case a | b:
            pass
        case value as name:
            pass
        case None:
            pass
        case _:
            pass


match = 1
case = 2
print(match, case)
