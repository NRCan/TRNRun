from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

DCK_FOLDER = Path(r"examples\dck")
CONFIG = SimulationConfig(watch_tmp=True)


def main() -> None:
    decks = sorted(DCK_FOLDER.glob("*.dck"))

    with SimulationManager(max_concurrent=4, max_pending=16) as manager:
        simulations = [manager.add(deck, CONFIG) for deck in decks]
        _ = manager.wait()

    for simulation in simulations:
        status_event = simulation.status
        status = status_event.status if status_event is not None else "UNKNOWN"
        print(f"{simulation.deck_path}: {status}")


if __name__ == "__main__":
    main()
