@simple
def one():
    pass


@module.attribute
def two():
    pass


@factory(1, key=2)
def three():
    pass


@first
@second
@third
def four():
    pass
