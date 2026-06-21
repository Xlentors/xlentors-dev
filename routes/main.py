from flask import Blueprint, render_template
from services.roblox import get_games_with_thumbnail
from services.firestore_service import increment_visitor_count, get_visitor_count, get_game_description

main_bp = Blueprint("main", __name__)


@main_bp.route("/")
def index():
    increment_visitor_count()
    visitor_count = get_visitor_count()
    games = get_games_with_thumbnail([9062242720, 10100036008])
    
    for game in games:
        game["description"] = get_game_description(game["id"])
         
    return render_template("index.html", games = games, visitor_count = visitor_count)
