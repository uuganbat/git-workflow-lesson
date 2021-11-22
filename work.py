class Decor(object):
    def __init__(self, name, description):
        self._name = name
        self._description = description

    def get_name(self):
        return self._name


if __name__ == '__main__':
    decor = Decor('Name of decor', 'Desc of decor')
    print(decor.get_name())
