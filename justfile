default: deploy

deploy:
    cd type3830 && nimble deploy
    cd runner && nimble deploy
    cd manager && uv build --wheel
