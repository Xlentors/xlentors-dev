from flask import Flask
from config import Config


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    from routes.main import main_bp
    app.register_blueprint(main_bp)

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(debug=True)
