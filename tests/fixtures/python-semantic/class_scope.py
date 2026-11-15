field = 1


class Holder:
    field = 2
    other = field

    def read(self):
        return field
