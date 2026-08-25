@component
class Widget {
    @observable name: string;

    @action.bound
    run(@inject() input: string): void {}
}
