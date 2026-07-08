import pickle

payload = b"not-a-real-pickle"
value = pickle.loads(payload)
