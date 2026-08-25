try:
    pass
except ValueError:
    pass

try:
    pass
except ValueError as error:
    pass
except (TypeError, KeyError):
    pass
else:
    pass
finally:
    pass

try:
    pass
except* ValueError:
    pass

try:
    pass
finally:
    pass
