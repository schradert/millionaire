import millionaire


class Millionaire:
    def __init__(self) -> None:
        # RPI doesn't support kexec
        millionaire.NixOS("piper", "piper", "--phases disko,install,reboot")


if __name__ == "__main__":
    Millionaire()
