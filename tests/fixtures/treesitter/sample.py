"""Sample module for tree-sitter symbol extraction tests."""


class Animal:
    def __init__(self, name):
        self.name = name

    def speak(self):
        raise NotImplementedError


class Dog(Animal):
    def speak(self):
        return "woof"


def make_dog(name):
    return Dog(name)
