from google.cloud import firestore

db = firestore.Client()

def increment_visitor_count():
    doc_ref = db.collection("stats").document("visitor_count")
    doc_ref.set(
        {"count": firestore.Increment(1)},
        merge = True
    )
    
def get_visitor_count() -> int:
    doc_ref = db.collection("stats").document("visitor_count")
    doc = doc_ref.get()
    
    if doc.exists:
        doc_dict = doc.to_dict()
        return doc_dict["count"]
    else:
        print("Document does not exist yet.")
        return 0
    
def get_game_description(universe_id: int) -> str:
    doc_ref = db.collection("game_descriptions").document(str(universe_id))
    doc = doc_ref.get()
    
    if doc.exists:
        doc_dict = doc.to_dict()
        return doc_dict["description"]
    else:
        print("Document does not exist")
        return "No desc yet."
        
if __name__ == "__main__":
    increment_visitor_count()
    visitors = get_visitor_count()
    print(visitors)