"""Queue job handle."""


class Job:
    def __init__(self, job_id, payload):
        self.id = job_id
        self.payload = payload
        self.acked = 0

    def ack(self):
        self.acked += 1
