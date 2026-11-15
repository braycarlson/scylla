class Empty:
    pass


class Simple(Base):
    field = 1

    def method(self):
        return self.field


class Keyworded(Base, metaclass=Meta):
    pass


class Multiple(One, Two, Three):
    class Inner:
        pass


@decorated
class Decorated:
    pass
