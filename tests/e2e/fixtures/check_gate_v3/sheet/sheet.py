"""A tiny spreadsheet. See README.md."""


class Sheet:
    def set(self, ref, raw):
        raise NotImplementedError

    def get(self, ref):
        raise NotImplementedError
