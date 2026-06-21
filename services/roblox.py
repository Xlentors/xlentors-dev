import requests

# helpers
def _build_ids_params(universe_ids: list) -> str:
    str_ids = []
    
    for uid in universe_ids:
        str_ids.append(str(uid))
        
    return ", ".join(str_ids)

# main functions
def get_games_stats(universe_ids: list) -> list[dict]:
    ids_str = _build_ids_params(universe_ids)
    
    url = f"https://games.roblox.com/v1/games?universeIds={ids_str}"
    
    try:
        r = requests.get(url, timeout = 5)
    except requests.exceptions.RequestException as e:
        print(f"Request failed: {e}")
        return []
        
    print(f"Status code: {r.status_code}")

    response = r.json()
    
    if r.status_code != 200:
        print(f"Roblox API returned an error: {response}")
        return []
    
    if "data" not in response:
        print(f"Unexpected response format: {response}")
        return []
        
    formatted_games = []
    
    for game_data in response["data"]:
        formatted_games.append(format_game(game_data))
    
    return formatted_games
    
def format_game(game_data: dict) -> dict:
    formatted_dict = {
        "id": game_data["id"],
        "name": game_data["name"],
        "created": game_data["created"],
        "visits": game_data["visits"],
        "url": f"https://www.roblox.com{game_data["canonicalUrlPath"]}"
    }
        
    return formatted_dict
    
def get_game_thumbnails(universe_ids: list) -> list[dict]:
    ids_str = _build_ids_params(universe_ids)
    
    url = f"https://thumbnails.roblox.com/v1/games/icons?universeIds={ids_str}&size=512x512&format=Png&isCircular=false"
    
    try:
        r = requests.get(url, timeout = 5)   
    except requests.exceptions.RequestException as e:
        print(f"Request failed: {e}")
        return []
    
    print(f"Status code: {r.status_code}")
    
    response = r.json()
    
    if r.status_code != 200:
        print(f"Roblox API returned an error: {response}")
        return []
    
    if "data" not in response:
        print(f"Unexpected response format: {response}")
        return []
    
    return response["data"]

def get_games_with_thumbnail(universe_ids: list) -> list[dict]:
    games = get_games_stats(universe_ids)
    thumbnails = get_game_thumbnails(universe_ids)
    
    thumbnail_lookup = {}
    
    for thumbnail in thumbnails:
        targetId = thumbnail["targetId"]
        imageUrl = thumbnail["imageUrl"]
        thumbnail_lookup[targetId] = imageUrl

    for game in games:
        game["thumbnail"] = thumbnail_lookup.get(game["id"])
    
    return games

if __name__ == "__main__":
    results = get_games_with_thumbnail([9062242720, 10100036008])
    print(results)
