import sys
from google.cloud import firestore

db = firestore.Client()

def set_description(universe_id: int, description: str):
    doc_ref = db.collection("game_descriptions").document(str(universe_id))
    doc_ref.set({"description": description})
    
if __name__ == "__main__":
    universe_id = sys.argv[1]
    description = sys.argv[2]
    set_description(universe_id, description)
    print(f"Description set for {universe_id}")